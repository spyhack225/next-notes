import Foundation

/// How far the watcher has read, and which rows it has already handed over.
///
/// **Two mechanisms, and the roadmap is explicit that both are required** (`00-README.md` §12
/// "Watermark"). `lastProcessedRowID` is the fast one: it makes `messages(after:)` cheap and
/// it is what makes ordering stable, because `ROWID` is the only ordering that survives a
/// row arriving late. On its own it is not enough, for three reasons the self-test pins:
///
/// 1. **Recovery rewinds it.** A crash between "read the row" and "persisted the watermark"
///    leaves a persisted value behind the truth, and the next pass re-reads rows the user
///    has already been told about. A row id cannot tell a re-read from a new row.
/// 2. **A row id is not an identity.** A restored backup, a re-imported history or a
///    rewritten `chat.db` can hand the same `guid` a different `ROWID`. Then the row id
///    calls it new and the user gets the same sentence twice.
/// 3. **A duplicate row is possible from the query itself.** `messages(after:chatGUID:)`
///    joins `chat_message_join`, and a message in two chats is returned twice on an
///    unfiltered pass.
///
/// The GUID cache is what covers all three, and it is bounded (see `guidCacheLimit`) because
/// an unbounded `Set<String>` on a machine that never quits is a slow leak. **The bound is
/// safe because the two mechanisms have different jobs.** The row id covers everything older
/// than the cache; the cache only has to span the window between the persisted watermark and
/// the truth, which is however many rows landed between two writes of the settings file.
/// Evicting beyond that can only cost a duplicate in a case that is already a duplicate.
///
/// **There is no store here.** `lastProcessedRowID` is persisted by IM-07's
/// `imessage-settings.json`, which the roadmap already names as its home, and this type is
/// the value that file holds. Adding a second file for it would be the second ledger
/// `AGENTS.md` warns about, and the self-test simulates a restart by carrying the value
/// across — which is the same thing a real store does and costs no write on a live database.
struct MessagesWatermark: Equatable, Sendable {
    /// The highest `message.ROWID` this watcher has taken responsibility for.
    ///
    /// "Taken responsibility for" rather than "finished": a row whose attachment join is
    /// still settling is claimed here before it is delivered, because the alternative is a
    /// watermark that only moves when a photo finishes downloading, and a row left below a
    /// watermark another row has passed is invisible from then on. See `claim(_:guid:)`.
    private(set) var lastProcessedRowID: Int64 = 0

    /// Recently claimed guids, oldest first. An array rather than a `Set` because eviction
    /// has to know which is oldest, and a `Set` cannot say.
    private(set) var processedMessageGUIDs: [String] = []

    /// The membership test. Separate from the array so eviction is one array removal and
    /// not a rehash.
    private var seen: Set<String> = []

    /// How many guids are remembered. 512 is roughly a day of a busy conversation and is
    /// bounded so the memory is bounded; the reasoning for why that is enough is the file
    /// header's.
    static let guidCacheLimit = 512

    /// Guids in the cache. Diagnostics and a test assertion, never a log of message text —
    /// a guid is an opaque handle, which is what the roadmap's §12 privacy rule allows.
    var guidCacheCount: Int { processedMessageGUIDs.count }

    /// Whether this guid has already been handed over.
    func isKnown(guid: String) -> Bool {
        !guid.isEmpty && seen.contains(guid)
    }

    /// Takes responsibility for one row.
    ///
    /// - Returns: `true` when this is the first time the watcher has seen the row, and
    ///   `false` when the guid was already claimed — in which case nothing else about the
    ///   row is read and nothing is delivered. The row id still advances, so a duplicate
    ///   arriving *behind* the watermark is not a reason to stall.
    /// - A row with an **empty** guid cannot be de-duplicated and is claimed on its row id
    ///   alone. `message.guid` is a `NOT NULL UNIQUE` column in every schema this has seen,
    ///   so that branch is defensive; it is not silent, because an empty key inserted into
    ///   the cache would make every guid-less row look like a duplicate of the first one.
    @discardableResult
    mutating func claim(rowID: Int64, guid: String) -> Bool {
        let fresh = !isKnown(guid: guid)
        if fresh, !guid.isEmpty { remember(guid) }
        advancePast(rowID: rowID)
        return fresh
    }

    /// Moves the row id forward. Never backwards — a caller that wants that is recovering,
    /// and says so through `rewind(to:)`.
    mutating func advancePast(rowID: Int64) {
        if rowID > lastProcessedRowID { lastProcessedRowID = rowID }
    }

    /// Recovery: the persisted row id is behind the truth because the process stopped
    /// between reading a row and persisting.
    ///
    /// The GUID cache is deliberately **not** cleared. Clearing it would make this a
    /// rewind-and-replay, and the replay is exactly the duplicate delivery the cache exists
    /// to prevent: the rows between the stale id and the cache's high-water mark are ones
    /// the user has already seen, and the cache is the only record that says so. This is
    /// the case the roadmap's second idempotency mechanism exists for, and it is
    /// `--selftest-imessage-watch`'s `replay_after_restart` case.
    mutating func rewind(to rowID: Int64) {
        guard rowID >= 0, rowID < lastProcessedRowID else { return }
        lastProcessedRowID = rowID
    }

    /// A snapshot for a settings file. Two scalars and an array, which is what IM-07's
    /// `imessage-settings.json` is for; nothing here writes anything itself.
    func snapshot() -> Snapshot {
        Snapshot(lastProcessedRowID: lastProcessedRowID, processedMessageGUIDs: processedMessageGUIDs)
    }

    /// Rebuilds a watermark from a snapshot. Absent guids decode as empty rather than
    /// failing: a settings file is written by more than one build, and the roadmap's own
    /// `decodeIfPresent` rule (`AgentTask`, `MemoryEntry`) applies to it for the same reason.
    init(snapshot: Snapshot) {
        self.lastProcessedRowID = snapshot.lastProcessedRowID
        var ordered: [String] = []
        var index: Set<String> = []
        for guid in snapshot.processedMessageGUIDs where !guid.isEmpty && index.insert(guid).inserted {
            ordered.append(guid)
        }
        self.processedMessageGUIDs = Array(ordered.suffix(Self.guidCacheLimit))
        self.seen = index
    }

    init() {}

    /// What a store writes. `Codable` because it is a value inside another value, and the
    /// keys are the two the roadmap names.
    struct Snapshot: Equatable, Sendable, Codable {
        var lastProcessedRowID: Int64
        var processedMessageGUIDs: [String]
    }

    private mutating func remember(_ guid: String) {
        processedMessageGUIDs.append(guid)
        seen.insert(guid)
        while processedMessageGUIDs.count > Self.guidCacheLimit {
            seen.remove(processedMessageGUIDs.removeFirst())
        }
    }
}

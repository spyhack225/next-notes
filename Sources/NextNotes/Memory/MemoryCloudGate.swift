import Foundation

/// The cloud backstop for the memory review (M2-a).
///
/// When OpenRouter rate-limits the review, every retry without a gate is another 429:
/// the scheduler burns through its queue returning nothing, and the ledger fills with
/// identical failures. The gate holds one date — when the cloud may be tried again — so
/// `route(.auto)` waits instead of calling, `enqueue()` and `harvestNewSources()` count
/// a reasoned skip instead of queueing work that cannot run, and the scheduler's
/// 1→5→15→60 backoff + 3×notice/10×disable (kept from `AgentScheduler`) has time to work.
///
/// Actor-isolated because `markRateLimited` arrives from a background URL session while
/// `isDown` is read on the main actor in `runOnce()`. The cached flag exists so the
/// synchronous `enqueue()` pre-create check — which cannot await — reads the same answer
/// the last async write left behind.
actor MemoryCloudGate {
    static let shared = MemoryCloudGate()

    /// When the cloud may be tried again. Nil means no known limit.
    private(set) var downUntil: Date?

    /// Reasoned skips while down, newest last. "Counted skip with reason" in M2-a.
    private(set) var skips: [(reason: String, at: Date)] = []

    /// Problem notices posted while down (at most one per down period).
    private(set) var notices = 0

    private var noticeForPeriod: Date?

    /// Synchronous mirror for the sync pre-create path. Updated on every write.
    nonisolated(unsafe) private static var cachedDownUntil: Date?

    init(downUntil: Date? = nil) {
        self.downUntil = downUntil
        Self.cachedDownUntil = downUntil
    }

    /// OpenRouter answered 429 (or equivalent). No job is created from this; the caller
    /// records the skip and the scheduler backs off.
    func markRateLimited(retryAfter: TimeInterval = 300, now: Date = Date(), reason: String = "OpenRouter is rate-limited") {
        let until = now.addingTimeInterval(max(60, retryAfter))
        downUntil = until
        Self.cachedDownUntil = until
    }

    func reset() {
        downUntil = nil
        Self.cachedDownUntil = nil
        skips = []
        notices = 0
        noticeForPeriod = nil
    }

    func isDown(now: Date = Date()) -> Bool {
        guard let until = downUntil else { return false }
        if now >= until {
            downUntil = nil
            Self.cachedDownUntil = nil
            return false
        }
        return true
    }

    /// A pre-create skip: counted, reasoned, no job queued. Returns the reason for the ledger.
    @discardableResult
    func recordSkip(reason: String, now: Date = Date()) -> String {
        skips.append((reason: reason, at: now))
        if skips.count > 200 { skips.removeFirst(skips.count - 200) }
        return reason
    }

    /// One notice per down period, not one per failure (M2-a fixture asserts this).
    func shouldNotify(now: Date = Date()) -> Bool {
        guard let until = downUntil else { return false }
        if noticeForPeriod == until { return false }
        noticeForPeriod = until
        notices += 1
        return true
    }

    var skipCount: Int { skips.count }

    /// What the sync `enqueue()` path reads. Same answer as the last async write.
    nonisolated static func isDownCached(now: Date = Date()) -> Bool {
        guard let until = cachedDownUntil else { return false }
        return now < until
    }

    nonisolated static func cachedReason() -> String {
        "OpenRouter is rate-limited — the review waits instead of retrying."
    }
}

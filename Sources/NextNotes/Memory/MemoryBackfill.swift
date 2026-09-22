import Foundation
import Observation

/// *Look through my past notes* — the one-time pass over everything already on this Mac.
///
/// Memory that only learns from what happens next is useless to someone who has been using
/// the app for weeks: on the machine this was written for, there were six recorded meetings,
/// 180 dictations and fourteen conversations before memory learned anything at all. The
/// backfill reads them once, with the same decision the live review makes — no separate
/// prompt, no separate guards, no lower bar.
///
/// It is **bounded** (a few sources per pass, so it never holds the model), **resumable**
/// (every source is ticked off in `MemoryReviewStateStore.harvested` as it finishes, so a
/// quit or a crash costs one source), **idempotent** (a ticked-off source is never read
/// again, and a fact already remembered is dropped as a near-duplicate), and **undoable** as
/// one batch, because it can add nine things at once and nobody asked for nine things.
struct MemoryBackfillState: Codable, Equatable, Sendable {
    var startedAt: Date?
    var finishedAt: Date?
    /// Entries this backfill saved, so the whole batch can be taken back with one button.
    var savedEntryIDs: [UUID] = []
    /// How many sources were waiting when it started, for the progress line.
    var total = 0
    /// How many have been read since it started.
    var done = 0
    /// The person dismissed the "I learned 9 things" summary.
    var summarySeenAt: Date?

    var isRunning: Bool { startedAt != nil && finishedAt == nil }
    var hasRun: Bool { finishedAt != nil }
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// "Looked through 12 of 186." / "I learned 9 things from your past notes."
    func progressLine() -> String {
        if isRunning { return "Looking through your past notes — \(done) of \(total)." }
        guard hasRun else { return "" }
        let count = savedEntryIDs.count
        if count == 0 { return "I looked through \(done) of your past notes and found nothing worth keeping." }
        return "I learned \(count) thing\(count == 1 ? "" : "s") from your past notes."
    }
}

/// Runs the backfill, a few sources at a time.
///
/// It shares the scheduler's queue rather than owning a second one: a backfill job is an
/// ordinary `MemoryReviewJob` with `.backfill` as its trigger, so it goes through the same
/// router (never while recording, never holding the local model), the same allowlist, the same guards
/// and the same ledger. The only difference is that its saves are collected into one batch.
@MainActor
@Observable
final class MemoryBackfill {
    static let shared = MemoryBackfill(scheduler: .shared)

    /// Sources per pass. Small enough that a pass finishes in well under a minute even on
    /// Apple Intelligence, so the next tick is never queued behind this one.
    static let sourcesPerPass = 4

    private let scheduler: MemoryReviewScheduler
    private(set) var isWorking = false

    init(scheduler: MemoryReviewScheduler) {
        self.scheduler = scheduler
    }

    var state: MemoryBackfillState { scheduler.state.backfill }

    /// Sources that have never been read, newest first.
    func pending() -> [MemoryReviewJob] {
        guard let store = scheduler.knowledgeStore else { return [] }
        return MemoryHarvest.documents(store: store, reviewed: scheduler.state.harvested)
    }

    /// Starts, or carries on, the one-time pass. Safe to call again: a pass already running
    /// returns immediately, and a finished backfill only restarts on `startAgain()`.
    @discardableResult
    func run(passes: Int = 1) async -> MemoryBackfillState {
        guard !isWorking else { return state }
        isWorking = true
        defer { isWorking = false }
        let waiting = pending()
        if scheduler.state.backfill.startedAt == nil {
            scheduler.state.updateBackfill {
                $0.startedAt = Date()
                $0.finishedAt = nil
                $0.total = waiting.count
                $0.done = 0
                $0.savedEntryIDs = []
                $0.summarySeenAt = nil
            }
        }
        for _ in 0..<max(1, passes) {
            let batch = Array(pending().prefix(Self.sourcesPerPass))
            guard !batch.isEmpty else {
                scheduler.state.updateBackfill { $0.finishedAt = Date() }
                break
            }
            for job in batch {
                let saved = await scheduler.runBackfill(job)
                scheduler.state.updateBackfill {
                    $0.done += 1
                    $0.savedEntryIDs += saved
                }
                // A recording started, or the route went away: stop cleanly and resume later.
                if scheduler.lastPassWaited { return state }
            }
            if pending().isEmpty {
                scheduler.state.updateBackfill { $0.finishedAt = Date() }
                break
            }
        }
        return state
    }

    /// Everything the backfill saved, still in the store.
    func learned() -> [MemoryEntry] {
        let ids = Set(state.savedEntryIDs)
        return scheduler.memory.entries.filter { ids.contains($0.id) }
    }

    /// Takes the whole batch back. The facts go, the sources stay ticked off — re-reading
    /// them would only put the same facts back.
    func undo() {
        for entry in learned() { try? scheduler.memory.forget(id: entry.id) }
        scheduler.state.updateBackfill { $0.savedEntryIDs = [] }
    }

    func markSummarySeen() {
        scheduler.state.updateBackfill { $0.summarySeenAt = Date() }
    }

    /// Runs it again over anything added since, which is the only reason to press the button
    /// twice. Already-read sources stay ticked off.
    func startAgain() {
        scheduler.state.updateBackfill {
            $0.startedAt = nil
            $0.finishedAt = nil
            $0.summarySeenAt = nil
        }
    }
}

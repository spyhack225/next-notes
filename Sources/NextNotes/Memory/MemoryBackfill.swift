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
    /// When the one-time repair re-opened a history that an unproductive pass had consumed.
    /// Optional so a file written before it existed still decodes — this struct is stored
    /// whole, and a new non-optional field would make every existing state file unreadable.
    var repairedAt: Date?

    var isRunning: Bool { startedAt != nil && finishedAt == nil }
    var hasRun: Bool { finishedAt != nil }
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// "Looked through 12 of 186." / "I learned 9 things from your past notes."
    func progressLine() -> String {
        // A pass resumed after the old counting bug can carry a `done` above `total`; the
        // line is still the person's, so it never reads "204 of 198".
        if isRunning { return "Looking through your past notes — \(min(done, total)) of \(total)." }
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
                // `savedEntryIDs` deliberately survives a restart: it is the batch the
                // "take them back" button undoes, and re-running over sources that are
                // already ticked off learns nothing — clearing it here made the first
                // batch un-undoable the moment the person looked again.
                $0.summarySeenAt = nil
            }
        }
        for _ in 0..<max(1, passes) {
            let batch = Array(pending().prefix(Self.sourcesPerPass))
            guard !batch.isEmpty else {
                scheduler.state.updateBackfill {
                    // Every source is read; `done` can only have been inflated by the old
                    // attempt-counting bug, and the finished line should not report a
                    // fraction of a pass that is over.
                    $0.done = max($0.done, $0.total)
                    $0.finishedAt = Date()
                }
                break
            }
            for job in batch {
                // `nil` means the source was not read — the route waited or the model failed.
                // It stays pending and `done` stays where it is: counting a skipped attempt as
                // progress is how the line read "152 of 198" while 46 sources had never been
                // opened, and how a pass that only waited looked finished.
                guard let saved = await scheduler.runBackfill(job) else { return state }
                scheduler.state.updateBackfill {
                    $0.done += 1
                    $0.savedEntryIDs += saved
                }
                // A recording started, or the route went away: stop cleanly and resume later.
                if scheduler.lastPassWaited { return state }
            }
            if pending().isEmpty {
                scheduler.state.updateBackfill {
                    $0.done = max($0.done, $0.total)
                    $0.finishedAt = Date()
                }
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

    /// One-time repair for a pass that ran while the review could not work.
    ///
    /// On this Mac the first backfill consumed all 198 sources and saved nothing (measured
    /// 22 Sep 2026): the Apple route could not answer the `<tool_call>` protocol, so every
    /// source was ticked off with a verdict that was wrong for all of them. A tick means
    /// "read and judged", and without this the repaired model would never see that history
    /// again. It runs **once** — `repairedAt` is the marker, and it lives in the state file —
    /// and only while the evidence still says the pass was unproductive: it finished, it
    /// saved nothing, and sources were consumed. Re-reading is safe: the duplicate and
    /// supersede rules that make the ordinary pass idempotent drop anything already known.
    func repairUnproductivePassIfNeeded() {
        let state = scheduler.state.backfill
        guard state.repairedAt == nil, state.hasRun, state.savedEntryIDs.isEmpty,
              !scheduler.state.harvested.isEmpty else { return }
        scheduler.state.updateBackfill { $0.repairedAt = Date() }
        Log.agent.info("memory backfill: re-opening \(self.scheduler.state.harvested.count, privacy: .public) sources consumed by an unproductive pass")
        startAgain()
    }

    /// *Look again at your past activity*: starts the pass over from the top, over
    /// everything the review has ever read — not only what arrived since.
    ///
    /// The sources are un-ticked here, deliberately. A pass that keeps its ticked-off list
    /// calls history read for ever, and this one was read while the on-device model could
    /// not answer the review at all: all 198 sources were consumed with nothing saved
    /// (measured 22 Sep 2026), so "already read" was a lie the user had no way to correct.
    /// Re-reading is safe rather than merely tolerable: a fact already remembered is
    /// dropped by the same duplicate and supersede rules that make the ordinary pass
    /// idempotent, so the second look cannot put anything in the list twice. The batch of
    /// saved entry ids survives on purpose — it is what the *take them back* action undoes.
    func startAgain() {
        scheduler.state.resetHarvest()
        scheduler.state.updateBackfill {
            $0.startedAt = nil
            $0.finishedAt = nil
            $0.summarySeenAt = nil
        }
    }
}

import Foundation
import Observation

/// The in-memory view of `runs.jsonl`, observed by every view that shows history.
///
/// It exists because `RunLog` is a file and SwiftUI can't watch one, so a mutation on
/// `RunLog` has to tell it. A recorded run is *appended* here rather than re-read: the file
/// is the same list in the same order, and re-parsing it after every hold put 177 KB
/// through `JSONDecoder` on the main actor to produce a list whose last row was already
/// known. Only the mutations that rewrite the file — an edit, a delete, a clear, a prune —
/// still reload, because only they can change anything the in-memory list got wrong.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [DictationRun] = []

    /// How many times this store has re-read the file.
    ///
    /// The one number `--selftest-dictation-hygiene` reads, because "a recorded run must not
    /// re-read `runs.jsonl`" is otherwise invisible from outside: the list looks the same
    /// either way, which is exactly how a store that re-parses the whole file on the main
    /// actor after every hold can look like one that does not.
    @ObservationIgnored private(set) var reloadCount = 0

    private init() { reload() }

    func reload() {
        reloadCount += 1
        runs = RunLog.load()
    }

    /// Zeroes the counter. Only a self-test calls this, and only immediately before the
    /// case it is measuring.
    func resetReloadCountForSelfTest() {
        reloadCount = 0
    }

    /// One newly recorded run, in the order it was written to the file.
    func append(_ run: DictationRun) {
        runs.append(run)
    }

    /// Compare mode: every engine's answer to one utterance, in the order they were filed.
    func append(contentsOf newRuns: [DictationRun]) {
        runs.append(contentsOf: newRuns)
    }

    /// Newest first — the order every list in the app wants.
    var newestFirst: [DictationRun] {
        runs.reversed()
    }

    /// Recordings grouped by comparison, newest first.
    var comparisons: [[DictationRun]] {
        Dictionary(grouping: runs.filter { $0.group != nil }, by: { $0.group! })
            .values
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }

    var singles: [DictationRun] {
        runs.filter { $0.group == nil }.reversed()
    }

    /// The most recent run that carries a cleanup record, and that record.
    ///
    /// Settings shows this so "what did it actually do to my words" is answerable from the
    /// app instead of from a JSONL file and a terminal. Older rows have no record, so this
    /// walks back rather than reading the last row and reporting nothing — after an upgrade
    /// the newest row is usually the only one that has one, but during a session where
    /// cleanup is switched off there may be several without.
    var lastCleanup: (run: DictationRun, record: CleanupRecord)? {
        for run in runs.reversed() {
            if let record = run.cleanup { return (run, record) }
        }
        return nil
    }
}

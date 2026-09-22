import Foundation
import Observation

/// The in-memory view of `runs.jsonl`, observed by every view that shows history.
///
/// It exists because `RunLog` is a file and SwiftUI can't watch one. Every mutation on
/// `RunLog` reloads this store, so the Dictation list and the Comparison section always
/// agree without either of them polling.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [DictationRun] = []

    private init() { reload() }

    func reload() {
        runs = RunLog.load()
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

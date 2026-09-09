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
}

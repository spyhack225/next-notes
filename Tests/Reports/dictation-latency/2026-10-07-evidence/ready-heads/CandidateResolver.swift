import Foundation
struct CandidateResolver {
let precleanGrace: Duration
let calls: DeadlineCalls
    func resolvePrecleanGroups(_ head: CleanupHead) async -> [String] {
        let deadline = ContinuousClock.now.advanced(by: precleanGrace)
        var pieces: [String] = []
        for (index, pair) in zip(head.stageA, head.cleaned).enumerated() {
            let (spoken, task) = pair
            let left = deadline - ContinuousClock.now
            // The same producer publishes this result just before returning its Task.
            // Ready groups need no deadline task pair or await. Preserve expiration,
            // cancellation and empty-answer behavior of the existing bounded wait.
            if left > .zero, !Task.isCancelled, head.completed.indices.contains(index),
               let landed = head.completed[index].value {
                pieces.append(landed.isEmpty ? spoken : landed)
                continue
            }
            if left > .zero, let landed = await countedBoundedWait(left, { await task.value }),
               !landed.isEmpty {
                pieces.append(landed)
            } else {
                // Not yet, or cancelled with the hold: the rules' own text, which is what
                // the same call returns when it runs out of time. Never a cancellation —
                // a landed answer is never thrown away to save a moment.
                pieces.append(spoken)
            }
        }
        return pieces
    }

func countedBoundedWait<T: Sendable>(_ duration: Duration, _ work: @escaping @Sendable () async -> T) async -> T? { calls.add(); return await withBoundedWait(duration, work) }
}

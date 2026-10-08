import Foundation
struct OriginalResolver {
let precleanGrace: Duration
let calls: DeadlineCalls
    func resolvePrecleanGroups(_ head: CleanupHead) async -> [String] {
        let deadline = ContinuousClock.now.advanced(by: precleanGrace)
        var pieces: [String] = []
        for (spoken, task) in zip(head.stageA, head.cleaned) {
            let left = deadline - ContinuousClock.now
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

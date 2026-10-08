import Foundation
private actor RaceGate<T: Sendable> {
    private var waiter: CheckedContinuation<T?, Never>?
    private var settled = false
    private var result: T?

    func settle(_ value: T?) {
        guard !settled else { return }
        settled = true
        result = value
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        }
    }

    func value() async -> T? {
        if settled { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}

func withBoundedWait<T: Sendable>(
    _ limit: Duration,
    joinCancelledWork: Bool = false,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let gate = RaceGate<T>()
    let job = Task(priority: .userInitiated) { await gate.settle(await work()) }
    let timer = Task {
        try? await Task.sleep(for: limit)
        await gate.settle(nil)
    }

    return await withTaskCancellationHandler {
        let result = await gate.value()
        timer.cancel()
        if result == nil {
            job.cancel()
            // Background voice ownership cannot report return while its SAME
            // cancelled child is still entered. Foreground callers keep their
            // existing bounded return; cancellation receipts never await this drain.
            if joinCancelledWork { await job.value }
        }
        return result
    } onCancel: {
        // A new spoken turn cancels the old planner's parent task. Without
        // forwarding that cancellation, its unstructured model job kept
        // running until the deadline and competed with live ASR/TTS.
        job.cancel()
        timer.cancel()
        Task { await gate.settle(nil) }
    }
}


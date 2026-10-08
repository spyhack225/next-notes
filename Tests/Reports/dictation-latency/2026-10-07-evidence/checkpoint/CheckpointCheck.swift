import Foundation

actor Completion {
    private(set) var done = false
    private(set) var cancelled = false
    func finish(_ cancelled: Bool) { self.cancelled = cancelled; done = true }
}

@main struct Check {
    static func until(_ condition: @Sendable () async -> Bool, milliseconds: Int = 100) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        } while ContinuousClock.now < end
        return await condition()
    }
    static func main() async {
        var failures = 0
        func check(_ name: String, _ valid: Bool) {
            if !valid { failures += 1; print("CHECKPOINT_WRONG: " + name) }
        }
        for workClass in [WorkClass.background, .meetingLive, .realtimeAgent] {
            for cancelBefore in [false, true] {
                let scheduler = ComputeScheduler()
                let owner = await scheduler.acquire(workClass)
                let high = await scheduler.acquire(.realtimeASR)
                let completion = Completion()
                let gate = AsyncStream<Void>.makeStream()
                let task = Task {
                    if cancelBefore { for await _ in gate.stream { break } }
                    await scheduler.checkpoint(owner)
                    await completion.finish(Task.isCancelled)
                }
                if cancelBefore {
                    task.cancel()
                    gate.continuation.yield(())
                    gate.continuation.finish()
                } else {
                    let registered = await until { await scheduler.hasCheckpointWaiterForProbe(owner) }
                    check("actual checkpoint registered", registered)
                    task.cancel()
                }
                let began = ContinuousClock.now
                let finished = await until { await completion.done }
                let snapshot = await scheduler.occupancy()
                check("cancelled \(workClass.rawValue) checkpoint joins before ASR release", finished)
                check("cancelled owner leaves existing parked queue", !snapshot.isBusy(workClass))
                check("cancellation preserves held ASR", snapshot.running == .realtimeASR && snapshot.realtimeASRBusy)
                await scheduler.release(high)
                await task.value
                check("same task retained cancellation", await completion.cancelled)
                await scheduler.release(owner)
                check("no parked/running/waiter leak", (await scheduler.occupancy()).busy.isEmpty)
                print("CHECKPOINT_OBSERVATION class=\(workClass.rawValue) before=\(cancelBefore) joinedWhileASRHeld=\(finished) cancellationWait=\(began.duration(to: .now))")
            }
        }
        for index in 0..<20 {
            let scheduler = ComputeScheduler()
            let owner = await scheduler.acquire(.background)
            let high = await scheduler.acquire(.realtimeASR)
            let task = Task { await scheduler.checkpoint(owner) }
            check("race checkpoint registered", await until { await scheduler.hasCheckpointWaiterForProbe(owner) })
            if index.isMultiple(of: 2) {
                task.cancel(); await scheduler.release(high)
            } else {
                await scheduler.release(high); task.cancel()
            }
            await task.value
            await scheduler.release(owner)
            check("release/cancel race leaves no jobs", (await scheduler.occupancy()).busy.isEmpty)
        }
        check("existing scheduling regressions", await ComputeScheduler.runSelfTest())
        print(failures == 0 ? "CHECKPOINT_OK" : "CHECKPOINT_FAILED: \(failures)")
    }
}

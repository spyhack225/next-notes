import Foundation

actor Hold {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}
struct HeldSemantic: TextFormatter {
    let gate: Hold
    let calls: LockedBox<[String]>
    func format(_ raw: String) async -> String {
        calls.value.append(raw)
        await gate.wait()
        return raw.uppercased()
    }
}
@main struct PrecleanCheck {
    static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .milliseconds(150)
        while ContinuousClock.now < limit {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
    static func main() async {
        var failures: [String] = []
        let gate = Hold()
        let calls = LockedBox<[String]>([])
        let session = IncrementalCleanupSession(semantic: HeldSemantic(gate: gate, calls: calls), rules: { $0 })
        let first = "The first group is waiting."
        let second = "The second group must be cancelled."
        let full = first + " " + second
        await session.notePartial(first, committed: first)
        if !(await waitUntil { calls.value.count == 1 }) { failures.append("first producer never entered semantic") }
        await session.notePartial(full, committed: full)
        if !(await waitUntil { await session.waitingGroupsForProbe() == 1 }) { failures.append("second producer never parked") }
        let head = await session.head()
        guard head.cleaned.count == 2 else {
            await gate.release()
            for task in head.cleaned { _ = await task.value }
            print("PRECLEAN_FAILED: wrong group count")
            return
        }
        let done = LockedBox(false)
        let firstDone = LockedBox(false)
        let secondResult = LockedBox<String?>(nil)
        let firstJoin = Task { _ = await head.cleaned[0].value; firstDone.value = true }
        let secondJoin = Task { secondResult.value = await head.cleaned[1].value; done.value = true }
        let began = ContinuousClock.now
        await session.cancel()
        let joinedWhileFirstHeld = await waitUntil { done.value }
        let delay = ContinuousClock.now - began
        if !joinedWhileFirstHeld { failures.append("cancelled second task still waits behind held first task") }
        if head.completed[1].value != second { failures.append("cancelled second completion is not available as exact raw group") }
        if firstDone.value { failures.append("cancelling waiter prematurely released the first semantic owner") }
        if calls.value != [first] { failures.append("cancelled second group entered semantic") }
        if head.rawPrefix != full || head.stageA != [first, second] { failures.append("original grouping or prefix changed") }
        await gate.release()
        await firstJoin.value
        await secondJoin.value
        if secondResult.value != second || calls.value != [first] { failures.append("final cancellation changed content or called semantic again") }
        if await session.waitingGroupsForProbe() != 0 { failures.append("waiter leaked after owner release") }
        // Normal ownership stays serial, and both original groups are cleaned.
        let ordinaryGate = Hold()
        let ordinaryCalls = LockedBox<[String]>([])
        let ordinary = IncrementalCleanupSession(semantic: HeldSemantic(gate: ordinaryGate, calls: ordinaryCalls), rules: { $0 })
        await ordinary.notePartial(first, committed: first)
        _ = await waitUntil { ordinaryCalls.value.count == 1 }
        await ordinary.notePartial(full, committed: full)
        _ = await waitUntil { await ordinary.waitingGroupsForProbe() == 1 }
        if ordinaryCalls.value != [first] { failures.append("normal lane admitted overlapping second semantic") }
        let ordinaryHead = await ordinary.head()
        await ordinaryGate.release()
        var ordinaryResults: [String] = []
        for task in ordinaryHead.cleaned { ordinaryResults.append(await task.value) }
        if ordinaryResults != [first.uppercased(), second.uppercased()] || ordinaryCalls.value != [first, second] { failures.append("normal lane lost original cleanup/order") }
        // Cancel and owner release are exercised in either order through the real session.
        for index in 0..<20 {
            let raceGate = Hold()
            let raceCalls = LockedBox<[String]>([])
            let raceSession = IncrementalCleanupSession(semantic: HeldSemantic(gate: raceGate, calls: raceCalls), rules: { $0 })
            await raceSession.notePartial(first, committed: first)
            _ = await waitUntil { raceCalls.value.count == 1 }
            await raceSession.notePartial(full, committed: full)
            _ = await waitUntil { await raceSession.waitingGroupsForProbe() == 1 }
            let raceHead = await raceSession.head()
            if index.isMultiple(of: 2) {
                await raceSession.cancel(); await raceGate.release()
            } else {
                async let cancellation: Void = raceSession.cancel()
                await raceGate.release()
                await cancellation
            }
            for task in raceHead.cleaned { _ = await task.value }
            if await raceSession.waitingGroupsForProbe() != 0 { failures.append("race \(index) leaked waiter") }
            if raceCalls.value.count > 2 || raceHead.rawPrefix != full { failures.append("race \(index) duplicated or lost group") }
        }
        print("PRECLEAN_MEASURE: joinedWhileFirstHeld=\(joinedWhileFirstHeld) wait=\(delay) semanticCalls=\(calls.value.count)")
        for failure in failures { print("FAIL: " + failure) }
        print(failures.isEmpty ? "PRECLEAN_OK" : "PRECLEAN_FAILED: \(failures.count)")
    }
}

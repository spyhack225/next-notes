import Foundation

protocol TextFormatter: Sendable { func format(_ raw: String) async -> String }

final class DeadlineCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

actor FixtureGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

struct FixtureFormatter: TextFormatter {
    let kind: Int
    let gate: FixtureGate?
    func format(_ raw: String) async -> String {
        if let gate { await gate.wait() }
        switch kind {
        case 1: return ""
        case 2: return " \n\t "
        case 3: return raw // Actual formatter error/fallback contract returns spoken text.
        default: return raw.uppercased()
        }
    }
}

@main struct ReadyHeadsCheck {
    static func produce(_ kind: Int, count: Int, gate: FixtureGate? = nil) async -> CleanupHead {
        let producer = IncrementalCleanupSession(
            semantic: FixtureFormatter(kind: kind, gate: gate), rules: { $0 })
        var committed = ""
        for index in 0..<count {
            let sentence = "The ready sentence has number \(index)."
            committed = CleanedText.joined([committed, sentence])
            await producer.notePartial(committed, committed: committed)
        }
        return await producer.head()
    }

    static func main() async {
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        for count in [1, 15, 30] {
            for kind in 0...3 {
                let head = await produce(kind, count: count)
                check(head.cleaned.count == count, "actual producer count \(count)")
                for task in head.cleaned { _ = await task.value }
                for expired in [false, true] {
                    let grace: Duration = expired ? .zero : .seconds(2)
                    let oldCalls = DeadlineCalls(), newCalls = DeadlineCalls()
                    let old = await OriginalResolver(precleanGrace: grace, calls: oldCalls)
                        .resolvePrecleanGroups(head)
                    let new = await CandidateResolver(precleanGrace: grace, calls: newCalls)
                        .resolvePrecleanGroups(head)
                    check(old == new, "ready exact fields count=\(count) kind=\(kind) expired=\(expired)")
                    check(newCalls.value == 0, "ready path started deadline workers")
                    check(oldCalls.value == (expired ? 0 : count), "original deadline path not exercised")
                    let expected = expired || kind == 1 || kind == 3 ? head.stageA :
                        head.stageA.map { kind == 2 ? " \n\t " : $0.uppercased() }
                    check(new == expected, "ready result changed empty/whitespace/raw contract")
                }
                let legacy = CleanupHead(rawPrefix: head.rawPrefix, cleaned: head.cleaned, stageA: head.stageA)
                let oldCalls = DeadlineCalls(), newCalls = DeadlineCalls()
                let old = await OriginalResolver(precleanGrace: .seconds(2), calls: oldCalls)
                    .resolvePrecleanGroups(legacy)
                let new = await CandidateResolver(precleanGrace: .seconds(2), calls: newCalls)
                    .resolvePrecleanGroups(legacy)
                check(old == new, "legacy result")
                check(newCalls.value == count && oldCalls.value == count, "legacy deadline not retained")
            }
        }
        for useCandidate in [false, true] {
            let release = FixtureGate()
            let head = await produce(0, count: 2, gate: release)
            let calls = DeadlineCalls()
            let output = useCandidate
                ? await CandidateResolver(precleanGrace: .milliseconds(5), calls: calls).resolvePrecleanGroups(head)
                : await OriginalResolver(precleanGrace: .milliseconds(5), calls: calls).resolvePrecleanGroups(head)
            check(output == head.stageA, "unfinished deadline changed spoken fallback")
            check(calls.value >= 1, "unfinished call bypassed deadline")
            await release.release()
            for task in head.cleaned { _ = await task.value }
            check(head.completed.allSatisfy { $0.value != nil }, "same producer did not publish after release")
        }
        // Cancellation race retains the original helper. Both spoken and an already
        // finished answer are allowed outcomes of the existing gate settlement race.
        for useCandidate in [false, true] {
            let head = await produce(0, count: 1)
            for task in head.cleaned { _ = await task.value }
            let start = FixtureGate(), calls = DeadlineCalls()
            let resolver = Task { () -> [String] in
                await start.wait()
                return useCandidate
                    ? await CandidateResolver(precleanGrace: .seconds(2), calls: calls).resolvePrecleanGroups(head)
                    : await OriginalResolver(precleanGrace: .seconds(2), calls: calls).resolvePrecleanGroups(head)
            }
            resolver.cancel()
            await start.release()
            let output = await resolver.value
            check(output == head.stageA || output == head.stageA.map { $0.uppercased() }, "cancelled result outside original race")
            check(calls.value == 1, "cancelled head took ready bypass")
        }
        let head = await produce(0, count: 30)
        for task in head.cleaned { _ = await task.value }
        for useCandidate in [false, true] {
            let calls = DeadlineCalls()
            let began = ContinuousClock.now
            for _ in 0..<300 {
                let output = useCandidate
                    ? await CandidateResolver(precleanGrace: .seconds(2), calls: calls).resolvePrecleanGroups(head)
                    : await OriginalResolver(precleanGrace: .seconds(2), calls: calls).resolvePrecleanGroups(head)
                check(output == head.stageA.map { $0.uppercased() }, "benchmark exact result")
            }
            let duration = began.duration(to: .now)
            print("READY_HEADS_COMPONENT: candidate=\(useCandidate) repeats=300 groups=30 deadlineCalls=\(calls.value) duration=\(duration)")
        }
        for failure in failures { print("READY_HEADS_WRONG: \(failure)") }
        print("READY_HEADS_\(failures.isEmpty ? "OK" : "FAILED"): checks=\(checks) problems=\(failures.count); exact production producer/resolver component only, full router/native unrun")
        if !failures.isEmpty { exit(1) }
    }
}

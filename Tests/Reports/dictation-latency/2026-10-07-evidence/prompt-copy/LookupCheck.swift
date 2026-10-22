import Foundation

@main struct LookupCheck {
    // Independent allocation-heavy reference checks all start positions forward,
    // retaining longest matches and then the latest valid continuation.
    static func reference(_ source: [Int32], _ history: [Int32], _ limit: Int) -> [Int32] {
        guard limit > 0, history.count >= 3, source.count > 3 else { return [] }
        var bestWidth = 0, bestEnd = -1
        for start in 0..<source.count {
            for width in 3...8 {
                let end = start + width
                if width > history.count || end >= source.count { continue }
                if Array(source[start..<end]) == Array(history.suffix(width)),
                   width > bestWidth || (width == bestWidth && end > bestEnd) {
                    bestWidth = width
                    bestEnd = end
                }
            }
        }
        guard bestEnd >= 0 else { return [] }
        return Array(source.dropFirst(bestEnd).prefix(limit))
    }

    static func main() {
        var failures = 0, checks = 0
        let limits = [-1, 0, 1, 2, 4, 8, Int.max]
        var state: UInt64 = 0x83a9
        func next() -> Int32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int32((state >> 40) % 11) - 5
        }
        for count in 0...90 {
            for iteration in 0..<30 {
                let source = (0..<count).map { _ in next() }
                let history: [Int32]
                if iteration % 3 == 0 && count > 4 {
                    let end = 3 + iteration % (count - 3)
                    history = Array(source[..<end].suffix(1 + iteration % 12))
                } else if iteration % 3 == 1 {
                    history = (0..<(iteration % 15)).map { _ in next() }
                } else {
                    history = Array(source.suffix(iteration % 12))
                }
                for limit in limits {
                    let proposed = LookupProducer.promptCopyDraft(source: source, history: history, limit: limit)
                    let expected = reference(source, history, limit)
                    checks += 1
                    if proposed != expected {
                        failures += 1
                        if failures < 8 { print("LOOKUP_WRONG: count=\(count) iteration=\(iteration) limit=\(limit)") }
                    }
                }
            }
        }
        for tuple: ([Int32], [Int32]) in [
            ([1,2,3,4,1,2,3,5], [1,2,3]),
            ([1,1,1,1,1,2], [1,1,1,1]),
            ([Int32.min,0,Int32.max,93], [Int32.min,0,Int32.max]),
            ([1,2,3,4,5,6,7,8,9], [1,2,3,4,5,6,7,8])
        ] {
            for limit in limits {
                checks += 1
                if LookupProducer.promptCopyDraft(source: tuple.0, history: tuple.1, limit: limit)
                    != reference(tuple.0, tuple.1, limit) { failures += 1 }
            }
        }
        // Lookup CPU only; actual native verification and batch numerical behavior
        // cannot be inferred from this result.
        for size in [100, 1500, 6000] {
            let source = (0..<size).map { _ in next() }
            let history = Array(source.suffix(8)) // End has no valid continuation.
            let began = ContinuousClock.now
            var total = 0
            for _ in 0..<1000 {
                total += LookupProducer.promptCopyDraft(source: source, history: history, limit: 4).count
            }
            print("LOOKUP_CPU: inputTokens=\(size) lookups=1000 proposed=\(total) duration=\(began.duration(to: .now))")
        }
        print("LOOKUP_\(failures == 0 ? "OK" : "FAILED"): checks=\(checks) failures=\(failures); native sampler/KV/accuracy/performance unrun")
        if failures != 0 { exit(1) }
    }
}

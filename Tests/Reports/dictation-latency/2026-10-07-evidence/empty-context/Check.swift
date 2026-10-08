import Foundation

@main struct Check {
    static func main() throws {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ description: String) {
            checks += 1
            if !value { failures.append(description) }
        }
        func same(_ a: ScreenContext, _ b: OriginalScreenContext) -> Bool {
            a.bundleID == b.bundleID && a.appName == b.appName
                && a.projectRoot == b.projectRoot && a.truncation.rawValue == b.truncation.rawValue
                && a.elapsed == b.elapsed && a.mentionCount == b.mentionCount
                && a.candidates.map { "\($0.kind.rawValue)|\($0.rank)|\($0.text)|\($0.path ?? "")" }
                == b.candidates.map { "\($0.kind.rawValue)|\($0.rank)|\($0.text)|\($0.path ?? "")" }
        }
        let prose = String(repeating: "We reviewed the recording and kept every word. Café e\u{301} 東京 Straße ﬃ 🎉. ", count: 80)
        let texts = ["", "Open login handler dot ts.", "東京 café 🎉", String(repeating: "We reviewed the recording and kept every word. Café e\u{301} 東京 Straße ﬃ 🎉. ", count: 3)]
        let limits = [-1, 0, 1, 3, 120, Int.max]
        let counts = [0, 1, 12, 200]
        for count in counts {
            let candidates = (0..<count).map { i in
                CandidateName(text: i == 0 ? "loginHandler.ts" : "file\(i).swift", path: "src/" + (i == 0 ? "loginHandler.ts" : "file\(i).swift"), kind: .sidebarFile, rank: i)
            }
            let old = candidates.map { OriginalCandidateName(text: $0.text, path: $0.path, kind: .sidebarFile, rank: $0.rank) }
            for mask: UInt8 in [0, 4, 127] {
                for project: String? in [nil, "publicFixture"] {
                    let current = ScreenContext(bundleID: "fixture.context", appName: "the fixture", candidates: candidates, projectRoot: project, truncation: .init(rawValue: mask), elapsed: .milliseconds(137))
                    let original = OriginalScreenContext(bundleID: "fixture.context", appName: "the fixture", candidates: old, projectRoot: project, truncation: .init(rawValue: mask), elapsed: .milliseconds(137))
                    for text in texts { for limit in limits {
                        check(same(current.narrowed(toMentionsIn: text, limit: limit), original.narrowed(toMentionsIn: text, limit: limit)), "exact fields count=\(count) mask=\(mask) project=\(project != nil) limit=\(limit)")
                    } }
                }
            }
        }
        let current = ScreenContext(bundleID: "fixture.context", appName: "the fixture", candidates: [], projectRoot: nil, truncation: [], elapsed: .zero)
        let original = OriginalScreenContext(bundleID: "fixture.context", appName: "the fixture", candidates: [], projectRoot: nil, truncation: [], elapsed: .zero)
        for limit in limits {
            check(same(current.narrowed(toMentionsIn: prose, limit: limit), original.narrowed(toMentionsIn: prose, limit: limit)), "long empty-context exact fields limit=\(limit)")
        }
        var sink = 0
        func measure(_ body: () -> Int) -> Double {
            let start = ContinuousClock.now
            for _ in 0..<100 { sink += body() }
            let d = start.duration(to: .now)
            return (Double(d.components.seconds) + Double(d.components.attoseconds)/1e18)*10
        }
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for round in 0..<4 {
            if round % 2 == 0 {
                oldTimes.append(measure { original.narrowed(toMentionsIn: prose).mentionCount })
                newTimes.append(measure { current.narrowed(toMentionsIn: prose).mentionCount })
            } else {
                newTimes.append(measure { current.narrowed(toMentionsIn: prose).mentionCount })
                oldTimes.append(measure { original.narrowed(toMentionsIn: prose).mentionCount })
            }
        }
        let report: [String: Any] = ["checks": checks, "failures": failures, "originalMillisecondsPerCall": oldTimes, "candidateMillisecondsPerCall": newTimes, "sink": sink, "scope": "Actual ScreenContext producer, actual signed-fifth NextNotesDictionary module/object; component only, no model/ASR/physical delivery"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        print(failures.isEmpty ? "EMPTY_CONTEXT_OK" : "EMPTY_CONTEXT_FAILED")
        if !failures.isEmpty { exit(1) }
    }
}

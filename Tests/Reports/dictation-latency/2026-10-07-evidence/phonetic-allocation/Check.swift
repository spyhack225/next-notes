import Foundation

@main
struct Check {
    static func main() throws {
        let args = CommandLine.arguments
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
        let names = fixtures["names"] as! [String]
        var checks = 0
        var failures: [String] = []
        func check(_ passed: Bool, _ label: String) {
            checks += 1
            if !passed { failures.append(label) }
        }
        func equal(_ a: SpokenForms.Match, _ b: OriginalSpokenForms.Match) -> Bool {
            a.score == b.score && a.spokenTokens == b.spokenTokens
                && a.matchedTokenCount == b.matchedTokenCount && a.nameTokenCount == b.nameTokenCount
                && a.namedExtension == b.namedExtension && a.namedOtherExtension == b.namedOtherExtension
                && a.isConfident == b.isConfident && a.isPlausible == b.isPlausible
        }
        let primaries = ["", "A", "AA", "é", "e\u{301}", "éx", "ß", "SS"]
        let alternates: [String?] = [nil, "", "A", "é", "e\u{301}", "SS"]
        for a in primaries { for aa in alternates { for b in primaries { for bb in alternates {
            let current = SpokenForms.PhoneticKey(primary: a, alternate: aa).matches(.init(primary: b, alternate: bb))
            let original = OriginalSpokenForms.PhoneticKey(primary: a, alternate: aa).matches(.init(primary: b, alternate: bb))
            check(current == original, "phonetic scalar pairing preserves arbitrary primary/alternate values")
        } } } }
        for v in vectors["scores"] as! [[String: Any]] {
            let spoken = v["spoken"] as! String, name = v["name"] as! String
            let a = SpokenForms.score(spoken: spoken, against: name)
            check(equal(a, OriginalSpokenForms.score(spoken: spoken, against: name)), "score equality: \(v["note"]!)")
            check(abs(a.score - (v["score"] as! Double)) <= 0.0005 && a.isConfident == (v["confident"] as! Bool)
                  && a.isPlausible == (v["plausible"] as! Bool)
                  && a.matchedTokenCount == (v["matchedTokenCount"] as! Int) && a.nameTokenCount == (v["nameTokenCount"] as! Int)
                  && a.namedExtension == (v["namedExtension"] as? Bool ?? false)
                  && a.namedOtherExtension == (v["namedOtherExtension"] as? Bool ?? false), "score truth: \(v["note"]!)")
        }
        for v in vectors["bestMatches"] as! [[String: Any]] {
            let text = v["transcript"] as! String, name = v["name"] as! String
            let a = SpokenForms.bestMatch(of: name, in: text)
            check(equal(a, OriginalSpokenForms.bestMatch(of: name, in: text)), "best equality: \(v["note"]!)")
            let span = v["spokenTokens"] as! [Int]
            check(abs(a.score - (v["score"] as! Double)) <= 0.0005 && a.isConfident == (v["confident"] as! Bool)
                  && a.spokenTokens == span[0]..<span[1], "best truth: \(v["note"]!)")
        }
        let own = SpokenForms.score(spoken: "typescript", against: "loginHandler.ts")
        check(abs(own.score - 0.08) < 0.0005 && own.matchedTokenCount == 0 && own.nameTokenCount == 2
              && own.namedExtension && !own.namedOtherExtension && own.spokenTokens == 0..<1, "own extension only")
        let unrelated = SpokenForms.score(spoken: "markdown", against: "loginHandler.ts")
        check(unrelated.score == 0 && unrelated.spokenTokens.isEmpty && !unrelated.namedExtension
              && !unrelated.namedOtherExtension, "unrelated extension only")
        let perfect = SpokenForms.bestMatch(of: "loginHandler.ts", in: "the login handler dot ts and the login handler dot ts")
        check(perfect.score == 1 && perfect.spokenTokens == 1..<3 && perfect.matchedTokenCount == 2
              && !perfect.namedExtension, "first perfect window")
        let aliasWords = Set(SpokenForms.extensionAliases.keys).union(SpokenForms.extensionAliases.values.flatMap { $0 })
        for ext in Array(SpokenForms.extensionAliases.keys) + ["txt", "go", "unknown", ""] {
            let name = ext.isEmpty ? "loginHandler" : "loginHandler." + ext
            for word in aliasWords.sorted() + ["ordinary", "東京", "café"] {
                for spoken in [word, "login handler " + word] {
                    check(equal(SpokenForms.score(spoken: spoken, against: name),
                                OriginalSpokenForms.score(spoken: spoken, against: name)), "extension contract " + name + ": " + spoken)
                }
            }
        }
        for v in fixtures["cases"] as! [[String: String]] {
            let text = v["input"]!
            for limit in [0, 1, 5, Int.max] {
                let a = FileReferences.tag(text, references: names, style: .atPath, looseMatchLimit: limit)
                let b = OriginalFileReferences.tag(text, references: names, style: .atPath, looseMatchLimit: limit)
                check(a.text == b.text && a.references == b.references, "tag equality limit\(limit): \(text)")
                if limit == Int.max { check(a.text == v["expected"]!, "tag truth: \(text)") }
                let c = FileReferences.tag(text, references: names, style: .backtickPath, looseMatchLimit: limit)
                let d = OriginalFileReferences.tag(text, references: names, style: .backtickPath, looseMatchLimit: limit)
                check(c.text == d.text && c.references == d.references, "backtick equality limit\(limit): \(text)")
            }
        }
        let prose = "We reviewed the recording with the team and checked whether everyone could follow the instructions. The first question was about improving the welcome experience. The second question concerned the account settings. We also discussed how people find documents and how they recover changes after an interruption. Please keep the existing behavior and make the interface easier to understand. Before the next release we should review the transcript together and check the entire flow. The purpose is to preserve every spoken detail without adding anything that was not said. Tomorrow the team can verify the result and prepare the final update. We need a clear explanation of what happened and a practical way to fix the remaining problems. Every person should be able to use the application without extra setup."
        let texts = [prose, "Open login handler dot ts and login handler dot ts again. " + prose,
                     prose + " Check the acoustic dash echo dot md file.",
                     "Café 🎉 a p i client swift then file store and login logout. " + prose,
                     "Open helpers dot ts. The logo file is here. " + prose]
        let candidates = (0..<200).map { i in
            CandidateName(text: "\(names[i % names.count])\(i / names.count)", path: names[i % names.count], kind: .sidebarFile, rank: i)
        }
        for text in texts {
            let a = SpokenForms.Heard(text), b = OriginalSpokenForms.Heard(text)
            for name in names + ["APIClient.swift", "v2.ts", "café-menu.md", "İstanbul.ts", "東京.swift", "fileStore.ts"] {
                check(equal(SpokenForms.bestMatch(of: name, in: a), OriginalSpokenForms.bestMatch(of: name, in: b)), "paragraph equality: \(name)")
            }
            for limit in [0, 1, 20, 120] {
                let a = ScreenContext(bundleID: "fixture", appName: "fixture", candidates: candidates, projectRoot: nil, truncation: [], elapsed: .zero).narrowed(toMentionsIn: text, limit: limit)
                let b = OriginalScreenContext(bundleID: "fixture", appName: "fixture", candidates: candidates, projectRoot: nil, truncation: [], elapsed: .zero).narrowed(toMentionsIn: text, limit: limit)
                check(a.candidates == b.candidates && a.mentionCount == b.mentionCount && a.truncation.rawValue == b.truncation.rawValue,
                      "actual context equality limit\(limit)")
            }
        }
        func measure(_ body: () -> Int) -> Double {
            let start = ContinuousClock.now
            var sink = 0
            for _ in 0..<3 { sink += body() }
            precondition(sink >= 0)
            let d = ContinuousClock.now - start
            return (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 / 3
        }
        var measurements: [[String: Any]] = []
        for (label, text) in [("no names", prose), ("name early", texts[1])] {
            let original = OriginalScreenContext(bundleID: "fixture", appName: "fixture", candidates: candidates, projectRoot: nil, truncation: [], elapsed: .zero)
            let current = ScreenContext(bundleID: "fixture", appName: "fixture", candidates: candidates, projectRoot: nil, truncation: [], elapsed: .zero)
            // Alternate ordering rather than timing every old call before every new one.
            let before1 = measure { original.narrowed(toMentionsIn: text).mentionCount }
            let after1 = measure { current.narrowed(toMentionsIn: text).mentionCount }
            let after2 = measure { current.narrowed(toMentionsIn: text).mentionCount }
            let before2 = measure { original.narrowed(toMentionsIn: text).mentionCount }
            measurements.append(["case": label, "old_ms": [before1, before2], "new_ms": [after1, after2], "candidates": candidates.count])
        }
        for limit in [0, 5, Int.max] {
            let text = texts[2]
            let before = measure { OriginalFileReferences.tag(text, references: names, style: .atPath, looseMatchLimit: limit).references.count }
            let after = measure { FileReferences.tag(text, references: names, style: .atPath, looseMatchLimit: limit).references.count }
            measurements.append(["case": "tag", "looseLimit": limit, "old_ms": before, "new_ms": after])
        }
        let result: [String: Any] = ["checks": checks, "failures": failures, "measurements": measurements,
                                   "scope": "actual Foundation-only original/current producers; no models, microphone, app or external insertion"]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}

import Foundation

struct IdentitySemantic: TextFormatter {
    let calls: LockedBox<[String]>
    func format(_ raw: String) async -> String { calls.value.append(raw); return raw }
}

@main struct StructurePrecleanCheck {
    struct Case: Sendable {
        let name: String
        let commits: [String]
        let final: String
        let mustReuse: Bool
    }
    static func main() async {
        let quote = "Open quote. We will deliver every required feature and preserve its exact meaning. End quote."
        let code = "Start code. npm run dev --host zero dot zero dot zero dot zero. End code."
        let list = "Start the list. First point, preserve the original dictated words and their meaning. Second point, preserve all file tags and final formatting. Close the list."
        let prose = "We will deliver every required feature and preserve its exact meaning."
        let tail = "The remaining sentence finishes later."
        let cases: [Case] = [
            Case(name: "closed-quote", commits: [quote], final: quote + " " + tail, mustReuse: true),
            Case(name: "closed-list", commits: [list], final: list + " " + tail, mustReuse: true),
            Case(name: "closed-code", commits: [code], final: code + " " + tail, mustReuse: true),
            Case(name: "ordinary", commits: [prose], final: prose + " " + tail, mustReuse: true),
            Case(name: "revised", commits: [prose], final: "We must retain the original words and their meaning. " + tail, mustReuse: false),
            Case(name: "cross-quote", commits: ["Open quote. We will deliver every required feature.", quote], final: quote + " " + tail, mustReuse: false),
            Case(name: "cross-list", commits: ["Start the list. First point, preserve the original dictated words and their meaning.", list], final: list + " " + tail, mustReuse: false),
            Case(name: "unicode", commits: ["ßeta is a named file and must retain all of its original content."], final: "ßeta is a named file and must retain all of its original content. " + tail, mustReuse: true)
        ]
        var checks = 0, originalMisses = 0, candidateMisses = 0, candidateOutputFailures = 0
        for markdown in [false, true] {
            let target = OutputProfile(bundleID: "fixture", displayName: "Fixture", capabilities: markdown ? Set(OutputCapability.allCases) : [])
            for enabled in [false, true] {
                for item in cases {
                    for candidate in [false, true] {
                        let log = LockedBox<[String]>([])
                        let formatter = IdentitySemantic(calls: log)
                        let rules: @Sendable (String) -> String = { raw in
                            let stageA = RuleBasedFormatter().apply(raw, isFinal: false)
                            return candidate ? SpokenStructure.apply(to: stageA, target: target, isEnabled: enabled).text : stageA
                        }
                        #if GROUP_PREPARE
                        let session = IncrementalCleanupSession(semantic: formatter,
                            rules: { RuleBasedFormatter().apply($0, isFinal: false) },
                            prepareGroup: { raw in
                                candidate ? SpokenStructure.apply(to: raw, target: target, isEnabled: enabled).text : raw
                            })
                        #else
                        let session = IncrementalCleanupSession(semantic: formatter, rules: rules)
                        #endif
                        for committed in item.commits { await session.notePartial(committed, committed: committed) }
                        let head = await session.head()
                        for task in head.cleaned { _ = await task.value }
                        let callsDuringHold = log.value
                        let stageA = RuleBasedFormatter().apply(item.final)
                        let before = SpokenStructure.apply(to: stageA, target: target, isEnabled: enabled).text
                        let remainder = head.stageA.isEmpty ? nil : PrefixContract.remainder(of: before, afterPrefix: head.rawPrefix)
                        let answer: String
                        if let remainder {
                            var parts: [String] = []
                            for task in head.cleaned { parts.append(await task.value) }
                            if !remainder.isEmpty { parts.append(await formatter.format(remainder)) }
                            #if PRESERVE_BOUNDARIES
                            if candidate, let separators = SourceBoundaryCandidate.separators(in: before, groups: head.stageA) {
                                answer = SourceBoundaryCandidate.joined(parts, separators: separators)
                            } else {
                                answer = CleanedText.joined(parts)
                            }
                            #else
                            answer = CleanedText.joined(parts)
                            #endif
                        } else {
                            answer = await formatter.format(before)
                        }
                        let after = SpokenStructure.apply(to: answer, target: target, isEnabled: enabled).text
                        let finalMatches = after == before
                        let shouldReuse = item.mustReuse
                        checks += 1
                        if shouldReuse && remainder == nil {
                            if candidate { candidateMisses += 1 } else { originalMisses += 1 }
                        }
                        if candidate && !finalMatches { candidateOutputFailures += 1 }
                        let row: [String: Any] = ["case":item.name,"markdown":markdown,"enabled":enabled,"candidate":candidate,"groups":head.cleaned.count,"headUsed":remainder != nil,"mustReuse":shouldReuse,"finalExact":finalMatches,"duringModelCalls":callsDuringHold.count,"keyUpModelCalls":log.value.count-callsDuringHold.count,"beforeModel":before,"head":head.rawPrefix,"output":after]
                        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let text = String(data:data,encoding:.utf8) { print(text) }
                        await session.cancel()
                    }
                }
            }
        }
        print("STRUCTURE_PRECLEAN_REVIEW: cases=\(checks) originalReuseMisses=\(originalMisses) candidateReuseMisses=\(candidateMisses) candidateExactOutputFailures=\(candidateOutputFailures)")
        // Diagnostic comparison: a failed candidate is retained, never promoted.
    }
}

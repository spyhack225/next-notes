import Foundation
import OSLog
// Only diagnostic sinks are supplied; both actual formatting producers/profile are intact.
enum Log { static let speech = Logger(subsystem: "dictation-pure-check", category: "fixture") }
enum SelfTest { static var outputPath: String? { nil } }
@main struct Check {
    static func main() async throws {
        var failures = OriginalSpokenStructure.selfTestFailures().map { "original: " + $0 }
        failures += SpokenStructure.selfTestFailures().map { "current: " + $0 }
        let md = OutputProfile(bundleID: "fixture", displayName: "fixture", capabilities: [.markdown, .bullets, .numbered, .tables, .code])
        let plain = OutputProfile.plain(bundleID: "fixture", displayName: "fixture")
        let prose = "We reviewed the recording with the team and checked whether everyone could follow the instructions. The first question was about improving the welcome experience. The second question concerned the account settings. We also discussed how people find documents and how they recover changes after an interruption. Please keep the existing behavior and make the interface easier to understand. Before the next release we should review the transcript together and check the entire flow. The purpose is to preserve every spoken detail without adding anything that was not said. Tomorrow the team can verify the result and prepare the final update. We need a clear explanation of what happened and a practical way to fix the remaining problems. Every person should be able to use the application without extra setup."
        let inputs = [prose, String(repeating: prose + " ", count: 5),
            "First point, milk. Second point, eggs. Third point, bread.",
            "Start the list. First point, ship the installer. Second point, write the release note. Close the list.",
            "Quote keep every detail end quote. That is the plan.",
            "Start code. npm run dev dash dash host. End code.",
            "First, café. Second, 東京. Third, 🎉 welcome.",
            "New paragraph. Um the the second question is why it is slow. That was very very good."]
        var comparisons = 0
        for text in inputs {
            for profile in [md, plain] {
                for enabled in [true, false] {
                    let old = OriginalSpokenStructure.apply(to: text, target: profile, isEnabled: enabled)
                    let new = SpokenStructure.apply(to: text, target: profile, isEnabled: enabled)
                    comparisons += 1
                    if old.text != new.text || old.applied.map(\.rawValue) != new.applied.map(\.rawValue)
                        || old.markersSeen != new.markersSeen {
                        failures.append("actual producer equality")
                    }
                    if new.markersSeen != SpokenStructure.containsMarkers(text) {
                        failures.append("full-scope marker result differs from repeated scan")
                    }
                }
            }
        }
        let parallel = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<4 { group.addTask { SpokenStructure.selfTestFailures() } }
            var failures: [String] = []
            for await result in group { failures += result }
            return failures
        }
        failures += parallel.map { "concurrent current: " + $0 }
        func measure(_ f: () -> Int) -> Double {
            let began = ContinuousClock.now
            var count = 0
            for _ in 0..<10 { count += f() }
            precondition(count > 0)
            let d = ContinuousClock.now - began
            return (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 / 10
        }
        var times: [[String: Any]] = []
        for (index, text) in inputs.prefix(3).enumerated() {
            let oldScan = measure { OriginalSpokenStructure.apply(to: text, target: md, isEnabled: true).text.count }
            let newScan = measure { SpokenStructure.apply(to: text, target: md, isEnabled: true).text.count }
            let oldThree = measure {
                let before = OriginalSpokenStructure.apply(to: text, target: md, isEnabled: true)
                _ = OriginalSpokenStructure.containsMarkers(text)
                let after = OriginalSpokenStructure.apply(to: text, target: md, isEnabled: true)
                return before.text.count + after.text.count
            }
            let newReuse = measure {
                let before = SpokenStructure.apply(to: text, target: md, isEnabled: true)
                _ = before.markersSeen
                return before.text.count + before.text.count
            }
            times.append(["case": index, "characters": text.count, "old_scan_ms": oldScan, "new_scan_ms": newScan,
                          "old_three_scans_ms": oldThree, "new_reuse_ms": newReuse])
        }
        print(String(data: try JSONSerialization.data(withJSONObject: ["comparisons": comparisons, "failures": failures,
            "maintained_original_and_current_structure_suite": failures.isEmpty,
            "concurrent_current_suite_runs": 4, "measurements": times,
            "scope": "actual original/current pure producers; diagnostic sinks supplied; reuse timing is a stage fixture, not whole router/model/UI acceptance"], options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The live half of P1-23: the questions that need a real Accessibility grant and a real window.
///
/// Y1–Y5, plus the **measurement the whole file rests on** — whether `eventSourceUserData`
/// survives `post(tap: .cghidEventTap)` and reads back in a listen-only tap. That question comes
/// first and is printed whether it succeeds or not, because "the tag does not survive" and "the
/// tag survives and the yield was 12 ms" are different sentences and the file header depends on
/// which one is true.
///
/// Red on a locked screen, like `--selftest-computer-actions`: the harness window is its own, but
/// a `CGEventTap` and a frontmost-app check both need an unlocked session. That is the
/// environment answer, not a pass, and it is reported as `COMPUTER_YIELD_NO_GRANT` rather than a
/// green.
@MainActor
enum ComputerYieldLiveSelfTest {

    /// The measured gap from the person's input to the agent's last posted event, in
    /// milliseconds. Zero when the live half did not run.
    static private(set) var lastLatencyMilliseconds = 0

    static func run() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        func note(_ line: String) { print("COMPUTER_YIELD: \(line)") }

        // The measurement, first, and on its own: a file that claims a tag works must have
        // watched it work on this machine.
        let tagWorks = HumanInputWatch.tagRoundTrip()
        note("eventSourceUserData round trip: \(tagWorks ? "survives" : "DOES NOT SURVIVE")")
        check("eventSourceUserData does not survive a post, so the tag cannot tell the two "
            + "hands apart", tagWorks)

        guard Permissions.hasAccessibility else {
            // Named, not folded into a pass. `--selftest-computer-actions` reports its own
            // absence the same way, and a self-test that says "OK" for a check it never ran is
            // the failure this whole workstream is about.
            note("no Accessibility grant: the live half did not run (launch with "
                + "--via-open on an unlocked screen)")
            return failures
        }
        guard HumanInputWatch.start() else {
            note("a listen-only CGEventTap could not be created, so the yield cannot be armed")
            return failures
        }
        defer { HumanInputWatch.stop() }

        let harness = ComputerSelfTestHarness()
        // `bringToFront` is the harness's own two-mechanism probe (activate, then
        // `kAXFrontmostAttribute`), measured; not a `show()` whose return value says nothing on
        // an agent-launched instance. A click against a window that never came forward would
        // land on whatever did, and Y1 would be measuring the wrong application entirely.
        guard harness.bringToFront() else {
            note("the harness window is not frontmost, so a click would land on whatever is "
                + "(this is the known red state on a locked screen)")
            return failures
        }

        // Y2 first, because it is the negative: tagged events alone must never pause. If the tag
        // were not read back, the agent's own clicks would pause it and every later case would
        // pass for the wrong reason.
        let tool = AgentToolRegistry.shared.tool(named: "computer.scroll")
            ?? AgentTool.native(namespace: .computer, name: "computer.scroll", description: "",
                                risk: .modify)
        HumanInputWatch.beginAction()
        _ = try? ComputerToolExecutor.run(tool, arguments: ["direction": "down", "amount": "3"])
        check("the agent's own events paused it (Y2)", HumanInputWatch.current == .driving)
        HumanInputWatch.endAction()

        // Y1: the person touches the Mac mid-scroll, and at most one more event goes out.
        HumanInputWatch.beginAction()
        HumanInputWatch.carryOn()
        let started = Date()
        let before = HumanInputWatch.postedSinceActionBegan
        // A person reaching for the mouse: an untagged mouse-down, which is what the real tap
        // reports and what this synthesises.
        postUntaggedMouseDown()
        let events = try? ComputerToolExecutor.run(
            tool, arguments: ["direction": "down", "amount": "10"])
        let after = HumanInputWatch.postedSinceActionBegan
        let latency = Int(Date().timeIntervalSince(started) * 1_000)
        lastLatencyMilliseconds = latency
        note("Y1: the person touched the Mac; the agent posted \\(after - before) further "
            + "event(s) and took \\(latency) ms to notice")
        check("Y1: the agent kept posting after the person took the Mac "
            + "(\\(after - before) more events)", (after - before) <= 1)
        check("Y1: the state is not paused after the person took the Mac",
              HumanInputWatch.current == .driving)
        check("Y1: the reply does not say it paused", events?.summary != HumanInputWatch.pausedSentence)
        check("Y1: the yield took \\(latency) ms, over the 100 ms target", latency <= 100)
        HumanInputWatch.endAction()

        // Carry on: a fresh snapshot, never the old coordinates.
        HumanInputWatch.notePauseForTesting(at: Date())
        check("a pause blocks the next event (Y3 setup)", HumanInputWatch.mayPostAnotherEvent() == false)
        HumanInputWatch.carryOn()
        check("Y3: carry on lets the next event through", HumanInputWatch.mayPostAnotherEvent())
        // The snapshot generation is what "a fresh snapshot" means here: the ids a plan would
        // reuse are the ones from the old walk, and a carry-on that reused them is the bug.
        let generationBefore = AccessibilitySnapshot.lastGenerationForTesting
        _ = try? ComputerToolExecutor.run(tool, arguments: ["direction": "down", "amount": "2"])
        check("Y3: carry on did not take a fresh snapshot "
            + "(generation \\(generationBefore))",
              AccessibilitySnapshot.lastGenerationForTesting != generationBefore)
        HumanInputWatch.endAction()

        // Y4/Y5: a secret is never filled. The harness carries a secure field for exactly this.
        HumanInputWatch.beginAction()
        let secure = AgentToolRegistry.shared.tool(named: "computer.set_text")
            ?? AgentTool.native(namespace: .computer, name: "computer.set_text", description: "",
                                risk: .modify)
        // The real walk, so the id below is one a plan would actually be handed.
        _ = AccessibilitySnapshot.captureCompact(
            processID: ProcessInfo.processInfo.processIdentifier, limit: 80)
        let secureID = AccessibilitySnapshot.lastSecureFieldIDForTesting
        if let secureID {
            let refused = try? ComputerToolExecutor.run(
                secure, arguments: ["id": secureID, "text": "hunter2"])
            check("Y4: a secure field accepted a typed value", refused?.summary
                != SecureFieldRule.refusalSentence(for: "This page"))
            check("Y4: the secure field is still empty", AccessibilitySnapshot.value(of: secureID) == "")
        } else {
            note("Y4: the harness's secure field was not in the snapshot; the rule is still "
                + "pinned by the grant-free table")
        }
        HumanInputWatch.endAction()

        return failures
    }

    /// A mouse-down with **no** tag, which is what the person's hand looks like to the tap.
    private static func postUntaggedMouseDown() {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }
}

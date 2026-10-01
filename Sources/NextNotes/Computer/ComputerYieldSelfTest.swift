import Foundation

/// P1-23: the person's hand always wins.
///
/// **Two halves, because the Accessibility grant is not available to a shell-launched
/// self-test** — AGENTS.md: TCC keys a grant to the responsible process, so the live half is
/// `via-open` and EXPERIMENTAL, like `--selftest-computer-actions`. The grant-free half runs in
/// INTEGRATION and pins everything that does not need a window: the tag, the sentence, the state
/// mapping, the refusal rule, and the decision table.
///
/// The live half answers the one question the file could not be written without — **does
/// `eventSourceUserData` survive `post(tap: .cghidEventTap)` and read back in a listen-only tap?**
/// — and then Y1–Y5 in a harness window. It prints the measured yield latency either way, so
/// "no grant" and "100 ms" are different sentences.
enum ComputerYieldSelfTest {

    /// The half that needs nothing. Returns its failures.
    ///
    /// `@MainActor` because `HumanInputWatch` is, and because the pause state it pokes is actor
    /// state. Nothing here needs a window or a grant — that is the point of the half.
    /// How many checks the grant-free half makes, for the marker's own sentence. Counted by
    /// running it, not by a hand-maintained number that drifts the first time a case is added.
    @MainActor
    static var grantFreeCount: Int { grantFreeCountStorage }

    /// Set by the last run. Named so it cannot be read as a count somebody maintains.
    nonisolated(unsafe) static var grantFreeCountStorage = 0

    @MainActor
    static func grantFreeFailures() -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append(name) }
        }
        defer { grantFreeCountStorage = checks }

        // UX06: the original two-task failure used a last-write-wins vision key as
        // the working card's image. Drive the actual capture publisher, then the card's
        // actual selector. No screen, grant, model or owner history is needed here.
        let activity = AgentActivityStore.shared
        activity.resetForSelfTest()
        let taskA = AgentTask(objective: "First window", source: "selftest")
        let taskB = AgentTask(objective: "Second window", source: "selftest")
        let imageA = LLMImage(data: Data([1]), mimeType: "image/jpeg", thumbnail: Data([11]), pixelWidth: 1, pixelHeight: 1)
        let imageB = LLMImage(data: Data([2]), mimeType: "image/jpeg", thumbnail: Data([22]), pixelWidth: 1, pixelHeight: 1)
        let key = "computer.screenshot"
        activity.begin(task: taskA, title: taskA.objective)
        activity.update(taskID: taskA.id, kind: .reading, title: "Looking at the first window")
        let bindingA = activity.presentationBinding(taskID: taskA.id)
        AgentWorkPresentationScope.$binding.withValue(bindingA) {
            ComputerToolExecutor.publishCapture(imageA, for: key, summary: "First window")
        }
        activity.begin(task: taskB, title: taskB.objective)
        activity.update(taskID: taskB.id, kind: .reading, title: "Looking at the second window")
        let bindingB = activity.presentationBinding(taskID: taskB.id)
        AgentWorkPresentationScope.$binding.withValue(bindingB) {
            ComputerToolExecutor.publishCapture(imageB, for: key, summary: "Second window")
        }
        check("the original shared-slot fixture was not reproduced",
              ScreenshotStore.peek(for: key)?.thumbnail == imageB.thumbnail)
        check("the first task showed the second task's capture",
              AgentWorkingCard.currentPreview(taskID: taskA.id, in: activity)?.thumbnail == imageA.thumbnail)
        check("the second task did not show its own capture",
              AgentWorkingCard.currentPreview(taskID: taskB.id, in: activity)?.thumbnail == imageB.thumbnail)
        _ = ScreenshotStore.take(for: key)
        check("consuming the vision capture erased the working card's preview",
              AgentWorkingCard.currentPreview(taskID: taskA.id, in: activity)?.thumbnail == imageA.thumbnail)
        ComputerToolExecutor.publishCapture(imageB, for: key, summary: "Unbound window")
        check("an unbound capture leaked into an active task",
              AgentWorkingCard.currentPreview(taskID: taskA.id, in: activity)?.summary == "First window"
              && AgentWorkingCard.currentPreview(taskID: taskB.id, in: activity)?.summary == "Second window")
        activity.update(taskID: taskA.id, kind: .reading, title: "Looking again")
        check("a new step retained the old window image",
              AgentWorkingCard.currentPreview(taskID: taskA.id, in: activity) == nil
              && activity.steps(taskID: taskA.id).first?.preview == nil)
        AgentWorkPresentationScope.$binding.withValue(bindingA) {
            ComputerToolExecutor.publishCapture(imageA, for: key, summary: "Late capture")
        }
        check("a late capture from an older step reached a newer step",
              AgentWorkingCard.currentPreview(taskID: taskA.id, in: activity) == nil)
        let freshA = activity.presentationBinding(taskID: taskA.id)
        AgentWorkPresentationScope.$binding.withValue(freshA) {
            activity.noteWindow("First window, updated")
            HumanInputWatch.stop()
            HumanInputWatch.notePauseForTesting(at: Date())
            if let click = AgentToolRegistry.shared.tool(named: "computer.click") {
                let result = try? ComputerToolExecutor.run(click, arguments: ["id": "1"])
                check("the actual backing did not yield before posting its next action",
                      result?.summary == HumanInputWatch.pausedSentence && HumanInputWatch.postedSinceActionBegan == 0)
            } else { check("the click backing fixture was absent", false) }
        }
        check("the producer's actual human pause did not reach the task's card",
              AgentWorkingCard.currentPreview(taskID: taskA.id, in: activity)?.isYielded == true)
        check("the first task's pause appeared on another task's card",
              AgentWorkingCard.currentPreview(taskID: taskB.id, in: activity)?.isYielded == false)
        activity.finish(taskID: taskA.id, title: "Finished")
        check("a finished task retained a window preview",
              activity.steps(taskID: taskA.id).last?.preview == nil)
        check("a finished task could bind another window observation",
              activity.presentationBinding(taskID: taskA.id) == nil)
        _ = ScreenshotStore.take(for: key)
        activity.resetForSelfTest()
        check("the reset retained preview state", activity.taskSteps.isEmpty)
        HumanInputWatch.stop()

        // The tag: one constant, and a value that reads as something.
        check("the agent event tag is not zero, or an untagged field would compare equal",
              HumanInputWatch.agentEventTag != 0)
        // The sentence: one line, plain words, and it says what to do.
        let sentence = HumanInputWatch.pausedSentence
        check("the pause sentence says the app paused: \\(sentence)",
              sentence.lowercased().contains("paused"))
        check("the pause sentence says the person is using the Mac: \\(sentence)",
              sentence.lowercased().contains("you\u{2019}re using the mac"))
        check("the pause sentence says how to continue: \\(sentence)",
              sentence.lowercased().contains("carry on"))
        for banned in ["AX", "CGEvent", "eventSourceUserData", "0x", "tool", "agent"] {
            check("the pause sentence contains \\(banned): \\(sentence)", sentence.contains(banned) == false)
        }
        check("the pause sentence is one line", sentence.contains("\n") == false)

        // The state mapping: what may post, and what carry-on does.
        HumanInputWatch.stop()
        HumanInputWatch.beginAction()
        check("a fresh action may post", HumanInputWatch.mayPostAnotherEvent())
        check("a fresh action is driving, not paused", HumanInputWatch.current == .driving)
        // A pause sticks. A person who reached for the mouse has not finished reaching for it,
        // and re-arming because the agent was impatient is how two hands end up on one pointer.
        HumanInputWatch.notePauseForTesting(at: Date())
        check("a pause blocks the next event", HumanInputWatch.mayPostAnotherEvent() == false)
        check("a pause is reported as paused", HumanInputWatch.current.isPaused)
        check("a pause stays a pause while the person keeps working",
              HumanInputWatch.mayPostAnotherEvent() == false)
        // Also preserve an event that has arrived but has not yet been latched as a
        // pause. The old beginAction cleared this before consulting the event ledger.
        HumanInputWatch.resetForNewTurn()
        HumanInputWatch.notePauseForTesting(at: Date())
        HumanInputWatch.arm(toolName: "click")
        check("arming an action erased pending human input", !HumanInputWatch.mayPostAnotherEvent())
        check("arming did not latch the person's pending input", HumanInputWatch.current.isPaused)
        // And across an action boundary, which is where the first version cleared it and the
        // agent resumed by itself on its next call.
        HumanInputWatch.endAction()
        HumanInputWatch.arm(toolName: "click")
        check("a pause did not survive the next action, so the agent resumed by itself",
              HumanInputWatch.mayPostAnotherEvent() == false)
        HumanInputWatch.endAction()
        // A new turn is the other way out, and the only other one.
        HumanInputWatch.resetForNewTurn()
        check("a new turn does not inherit the previous turn's pause",
              HumanInputWatch.mayPostAnotherEvent())
        HumanInputWatch.notePauseForTesting(at: Date())
        HumanInputWatch.resetForNewTurn()
        check("a new turn leaves the Mac to the person again",
              HumanInputWatch.mayPostAnotherEvent())
        HumanInputWatch.carryOn()
        check("carry on lets the next event through again", HumanInputWatch.mayPostAnotherEvent())
        check("carry on is not a pause", HumanInputWatch.current == .driving)
        HumanInputWatch.stop()

        // Reads do not take the hand; writes do.
        for read in ["active_app", "windows", "inspect_ui", "screenshot", "get_selection",
                     "clipboard", "wait_for", "snapshot"] {
            check("a read takes the hand: \\(read)", HumanInputWatch.touchesTheMac(read) == false)
        }
        for write in ["click", "type", "set_text", "press_key", "scroll", "drag", "double_click",
                      "right_click", "open_url", "open_app", "focus", "fill"] {
            check("a write does not take the hand: \\(write)",
                  HumanInputWatch.touchesTheMac(write))
        }

        // The refusal rule, as a table. Every case is a role or a declared `type`; none is text.
        for (role, type, secure, expected) in [
            ("AXSecureTextField", nil, false, true),
            ("AXTextField", nil, false, false),
            ("AXTextField", nil, true, true),
            (nil, "password", false, true),
            (nil, "PASSWORD", false, true),
            (nil, "cc-number", false, true),
            (nil, "cc-csc", false, true),
            (nil, "text", false, false),
            (nil, "email", false, false),
            (nil, nil, false, false),
        ] as [(String?, String?, Bool, Bool)] {
            // Broken up because the whole expression in one `check` is the shape the type
            // checker gives up on, and a self-test that does not compile is not a self-test.
            let refused = SecureFieldRule.refusal(role: role, inputType: type, secure: secure)
            let label = "role=\(role ?? "-") type=\(type ?? "-") secure=\(secure)"
            check("a secret check for \(label) is \(refused != nil), expected \(expected)",
                  (refused != nil) == expected)
        }
        check("an ordinary text field is not a secret — refusing every one would make the rule "
            + "refuse the whole app",
              SecureFieldRule.refusal(role: "AXTextField", inputType: "text", secure: false) == nil)
        check("a payment field says so rather than calling itself a sign-in",
              SecureFieldRule.refusal(role: nil, inputType: "cc-number") == .paymentField)
        check("a password says so rather than calling itself a payment",
              SecureFieldRule.refusal(role: nil, inputType: "password") == .secureField)
        // The sentences: one per reason, and none of them asks a model anything.
        for refusal in [SecureFieldRule.Refusal.secureField, .paymentField, .captcha] {
            let said = refusal.sentence
            check("the refusal for \\(refusal) names what needs the person: \\(said)",
                  said.contains("sign in"))
            check("the refusal for \\(refusal) says the app will carry on: \\(said)",
                  said.lowercased().contains("carry on"))
            for banned in ["AX", "selector", "querySelector", "model", "password"] {
                check("the refusal contains \\(banned): \\(said)", said.contains(banned) == false)
            }
        }
        check("the DOM selector is a selector and not a guess",
              SecureFieldRule.domSelector.contains("password"))
        return failures
    }

    @MainActor
    static func report(_ failures: [String], marker: String) {
        for failure in failures { print("COMPUTER_YIELD_WRONG: \(failure)") }
        print(failures.isEmpty ? marker : "COMPUTER_YIELD_FAILED: \(failures.count) problem(s)")
    }
}

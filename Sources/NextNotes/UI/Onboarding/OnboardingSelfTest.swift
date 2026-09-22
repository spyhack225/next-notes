import Foundation

/// `--selftest-onboarding` — the first-run state machine, with nothing on screen.
///
/// Deliberately pure. It never touches TCC, never starts a download and never opens a
/// window, because none of those can be answered from a terminal and the one question that
/// *can* be is the one that matters: **can a required screen be jumped, and can an optional
/// one be passed?** Every other check here exists so that a refactor which quietly reorders
/// the flow, forgets to save progress, or shows setup to somebody who already finished it
/// fails loudly instead of shipping.
@MainActor
enum OnboardingSelfTest {
    static func run() -> Bool {
        print("ONBOARDING: first-run state machine")
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                SelfTest.diagnostic("  ok   \(message)")
            } else {
                SelfTest.diagnostic("  FAIL \(message)")
                failures.append(message)
            }
        }

        // MARK: Order

        let expectedOrder: [OnboardingStep] = [
            .welcome, .dictation, .shortcut, .meetings, .files, .brain, .allSet,
        ]
        expect(OnboardingFlow.order == expectedOrder,
               "order is welcome → dictation → shortcut → meetings → files → brain → all set")
        expect(OnboardingFlow().total == expectedOrder.count, "seven screens")

        // MARK: Which screens may be passed over

        let optional = OnboardingFlow.order.filter(\.isOptional)
        expect(optional == [.meetings, .files], "only meetings and files are optional")
        let required = OnboardingFlow.order.filter { !$0.isOptional }
        expect(required == [.welcome, .dictation, .shortcut, .brain, .allSet],
               "welcome, dictation, shortcut, brain and all set are required")

        // MARK: A required screen cannot be bypassed
        //
        // The assertion this whole flag exists for. `skip()` on a required screen must
        // refuse *and leave the user where they were* — a refusal that still moves is the
        // same bug wearing a return value.
        for step in required {
            var flow = OnboardingFlow(resumingAt: step)
            let moved = flow.skip()
            expect(!moved, "skip refused on \(step.rawValue)")
            expect(flow.current == step, "skip left \(step.rawValue) in place")
            expect(!flow.skipped.contains(step), "\(step.rawValue) not marked as skipped")
            expect(!flow.isComplete, "skip on \(step.rawValue) did not complete setup")
        }

        // MARK: An optional screen can be passed over

        for step in optional {
            var flow = OnboardingFlow(resumingAt: step)
            let index = flow.index
            let moved = flow.skip()
            expect(moved, "skip accepted on \(step.rawValue)")
            expect(flow.index == index + 1, "skip moved on from \(step.rawValue)")
            expect(flow.skipped.contains(step), "\(step.rawValue) remembered as skipped")
        }

        // MARK: Walking the whole flow

        var walk = OnboardingFlow()
        var seen: [OnboardingStep] = [walk.current]
        // Bounded: a cycle in `advance()` would otherwise hang the test rather than fail it.
        for _ in 0..<(expectedOrder.count * 2) where !walk.isLast {
            walk.advance()
            seen.append(walk.current)
        }
        expect(seen == expectedOrder, "continue visits every screen once, in order")
        expect(!walk.isComplete, "reaching the last screen is not the same as finishing")
        expect(walk.advance() == false, "continue on the last screen has nowhere to go")
        expect(walk.isComplete, "continue on the last screen finishes setup")

        // MARK: Back

        var backward = OnboardingFlow(resumingAt: .files, skipped: [.meetings])
        expect(backward.back(), "back leaves files")
        expect(backward.current == .meetings, "back lands on meetings")
        expect(backward.skipped.contains(.meetings), "back kept the skip mark")
        var atStart = OnboardingFlow()
        expect(atStart.back() == false, "back on the first screen does nothing")
        expect(atStart.current == .welcome, "…and stays on welcome")

        // Continuing off a skipped screen clears its mark: the user has now been through it.
        var reconsidered = OnboardingFlow(resumingAt: .meetings, skipped: [.meetings])
        reconsidered.advance()
        expect(!reconsidered.skipped.contains(.meetings), "continuing off a skipped screen un-skips it")

        // MARK: Resume after a quit
        //
        // Its own defaults domain, so the user's real preferences are neither read nor
        // written. Removed at the end whatever happens.
        let suiteName = "NextNotesOnboardingSelfTest-\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            SelfTest.diagnostic("  FAIL could not open a scratch preferences domain")
            SelfTest.diagnostic("ONBOARDING_FAILED")
            return false
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        var completionEvents: [Bool] = []
        let first = OnboardingModel(defaults: scratch)
        first.onCompletionChanged = { completionEvents.append($0) }
        expect(first.step == .welcome, "a fresh Mac starts on welcome")
        first.advance()
        first.advance()
        expect(first.step == .shortcut, "two continues reach the shortcut screen")
        expect(first.skip() == false, "the shortcut screen refuses to be skipped")
        first.advance()
        expect(first.skip(), "the meetings screen can be skipped")

        let resumed = OnboardingModel(defaults: scratch)
        expect(resumed.step == .files, "a relaunch resumes where the user left off")
        expect(resumed.wasSkipped(.meetings), "a relaunch remembers what was skipped")
        expect(!resumed.isComplete, "a half-finished run is not a finished one")

        // MARK: Completion, and not showing setup twice

        expect(OnboardingPolicy.shouldPresent(hasCompleted: false, isSelfTest: false),
               "setup is shown on a Mac that has never seen it")
        expect(!OnboardingPolicy.shouldPresent(hasCompleted: true, isSelfTest: false),
               "setup is not shown again once it is finished")
        expect(!OnboardingPolicy.shouldPresent(hasCompleted: false, isSelfTest: true),
               "setup is never shown during a self-test")

        resumed.onCompletionChanged = { completionEvents.append($0) }
        resumed.advance()   // files → brain
        resumed.advance()   // brain → all set
        expect(resumed.isLast, "two more continues reach the last screen")
        resumed.finish()
        expect(resumed.isComplete, "Done finishes setup")
        expect(completionEvents == [true], "the rest of the app was told exactly once")
        expect(scratch.bool(forKey: OnboardingModel.Key.completed), "the completion flag was written")

        let afterDone = OnboardingModel(defaults: scratch)
        expect(afterDone.isComplete, "a relaunch reads the completion flag back")
        expect(!OnboardingPolicy.shouldPresent(hasCompleted: afterDone.isComplete, isSelfTest: false),
               "a relaunch after Done does not show setup")

        // MARK: Run setup again

        afterDone.onCompletionChanged = { completionEvents.append($0) }
        afterDone.restart()
        expect(afterDone.step == .welcome, "Run setup again starts at the beginning")
        expect(!afterDone.isComplete, "Run setup again clears the completion flag")
        expect(!afterDone.wasSkipped(.meetings), "Run setup again forgets what was skipped")
        expect(completionEvents == [true, false], "the rest of the app was told it is unfinished again")
        expect(OnboardingPolicy.shouldPresent(hasCompleted: afterDone.isComplete, isSelfTest: false),
               "setup is shown again after Run setup again")

        // MARK: The ending tells the truth
        //
        // The last screen used to congratulate everybody identically — same headline, same
        // "Hold Fn and talk", on a Mac that had been allowed neither to hear nor to type.
        // These assertions are the reason it cannot go back to that.

        let granted = OnboardingOutcome(
            hasMicrophone: true,
            hasAccessibility: true,
            hasCalendar: true,
            assistantName: "Ada",
            holdKeyName: "Fn"
        )
        expect(granted.canDictate, "both switches on is dictation")
        expect(granted.headline == "You're all set", "a finished setup says so")
        expect(granted.tips.first?.title == "Hold Fn and talk", "…and opens with the key to hold")
        expect(granted.tips.allSatisfy { !$0.isOutstanding }, "…with nothing left outstanding")

        for missing in [
            OnboardingOutcome(hasMicrophone: false, hasAccessibility: false),
            OnboardingOutcome(hasMicrophone: true, hasAccessibility: false),
            OnboardingOutcome(hasMicrophone: false, hasAccessibility: true),
            // Trusted by macOS and still not armed — the stale-signature trap.
            OnboardingOutcome(hasMicrophone: true, hasAccessibility: true, isTypingBlocked: true),
        ] {
            let label = "mic \(missing.hasMicrophone), typing \(missing.hasAccessibility)"
                + (missing.isTypingBlocked ? ", blocked" : "")
            expect(!missing.canDictate, "not dictation: \(label)")
            expect(missing.headline != "You're all set", "no all-set claim: \(label)")
            expect(missing.tips.first?.isOutstanding == true,
                   "the ending opens with what is still missing: \(label)")
            expect(!missing.tips.contains { $0.title.hasPrefix("Hold ") },
                   "the ending never tells them to hold the key: \(label)")
        }

        // A screen that was passed over is never named back at the user as something they set up.
        let declined = OnboardingOutcome(
            hasMicrophone: true,
            hasAccessibility: true,
            skippedMeetings: true,
            skippedFiles: true,
            hasCalendar: true,
            indexesFiles: true,
            assistantName: "Ada"
        )
        expect(!declined.tips.contains { $0.symbol == "calendar" || $0.symbol == "folder" },
               "a skipped screen is not claimed on the last one")
        let kept = OnboardingOutcome(
            hasMicrophone: true,
            hasAccessibility: true,
            hasCalendar: true,
            indexesFiles: true,
            assistantName: "Ada"
        )
        expect(kept.tips.contains { $0.symbol == "folder" },
               "a screen that was answered is worth a tip")

        // …and the same through the production path, so the skip marks have a reader that
        // is not this file. `OnboardingModel.wasSkipped` had none at all until now.
        let marked = OnboardingModel(defaults: scratch)
        marked.advance()    // welcome  → dictation
        marked.advance()    // dictation → shortcut
        marked.advance()    // shortcut → meetings
        expect(marked.step == .meetings, "three continues reach the meetings screen")
        expect(marked.skip(), "…which can be passed over")
        let scratchFolders = IndexedFoldersStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "NextNotesOnboardingSelfTest-folders-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        )
        let live = OnboardingOutcome.live(
            assistantName: "Ada",
            hasMicrophone: true,
            hasAccessibility: true,
            isTypingBlocked: false,
            hasCalendar: true,
            model: marked,
            folders: scratchFolders
        )
        expect(live.skippedMeetings, "the last screen is told meetings was passed over")
        expect(!live.tips.contains { $0.symbol == "calendar" },
               "…so it never offers to sit in on one")

        // MARK: Picking up an unfinished download
        //
        // Setup promises the transfer resumes. Before `OnboardingModelResume` nothing
        // resumed it, on a screen that can never be shown again.

        var reachedBrain = OnboardingFlow()
        expect(!reachedBrain.hasReached(.brain), "welcome has not promised an assistant")
        for _ in 0..<5 { reachedBrain.advance() }
        expect(reachedBrain.current == .brain, "five continues reach the assistant screen")
        expect(reachedBrain.hasReached(.brain), "…and that screen makes the promise")
        expect(OnboardingFlow(resumingAt: .allSet).hasReached(.brain), "so does anything past it")

        let gigabyte: Int64 = 1_024 * 1_024 * 1_024
        func resumes(
            promised: Bool = true,
            selfTest: Bool = false,
            downloaded: Bool = false,
            busy: Bool = false,
            free: Int64 = 40 * gigabyte,
            since: TimeInterval? = nil
        ) -> Bool {
            OnboardingModelResume.shouldResume(
                wasPromised: promised,
                isSelfTest: selfTest,
                isDownloaded: downloaded,
                isBusy: busy,
                freeBytes: free,
                requiredBytes: 8 * gigabyte,
                secondsSinceLastAttempt: since
            )
        }
        expect(resumes(), "an unfinished download is picked up again")
        expect(!resumes(promised: false), "a Mac that was never shown the screen is left alone")
        expect(!resumes(selfTest: true), "a self-test never starts a download")
        expect(!resumes(downloaded: true), "nothing is fetched twice")
        expect(!resumes(busy: true), "a download in flight is not restarted")
        expect(!resumes(free: 4 * gigabyte), "a full disk is not filled the rest of the way")
        expect(!resumes(since: 5), "two attempts in a row are not made back to back")
        expect(resumes(since: OnboardingModelResume.retryInterval + 1),
               "…but the next one comes after the interval")

        if failures.isEmpty {
            SelfTest.diagnostic("ONBOARDING_OK")
            return true
        }
        SelfTest.diagnostic("ONBOARDING: \(failures.count) failed — \(failures.joined(separator: "; "))")
        SelfTest.diagnostic("ONBOARDING_FAILED")
        return false
    }
}
